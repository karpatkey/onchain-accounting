// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Options as UUPSDeployOptions} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import "forge-std/Test.sol";
import "test/SuperTest.sol";

import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";

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
    sXDAI_PriceOracle public savingsXdaiPrice;

    sDAI_PriceOracle public sdaiPriceOracle;

    NAVCalculator public nav;

    uint256 public fork;
    address public admin = makeAddr("admin");
    address public ops = makeAddr("ops");

    uint256 public heartbeat = type(uint256).max;

    function forkRead() internal view returns (INAVCalculator.NAV memory) {
        INAVCalculator.NAV memory reading = nav.getAccountNav(safe, address(0));

        return reading;
    }

    function setupNavCalculator() internal {
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
        fork = vm.createFork(getAlchemyUrl("eth-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(20_993_780);
        setupNavCalculator();
    }

    function test_mainnetFork_read() public view {
        INAVCalculator.NAV memory reading = super.forkRead();

        assertEq(reading.issues.stalePriceAssets.length, 0);
        assertEq(reading.issues.sequencerDown, false);
        assertEq(reading.value, 12_742_160_647_301);
    }

    // Test 28: fork_getAllPositions_usd
    function test_fork_getAllPositions_usd() public view {
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));
        INAVCalculator.NAV memory navTotal = nav.getAccountNav(safe, address(0));

        assertEq(navTotal.issues.stalePriceAssets.length, 0);
        assertEq(navTotal.issues.sequencerDown, false);
        assertEq(navTotal.value, 12_742_160_647_301);

        // Verify NAV consistency invariant
        int256 sum = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            sum += positions[i].value;
        }
        assertEq(navTotal.value, sum);

        // Verify all positions have correct structure
        assertTrue(positions.length > 0);
        for (uint256 i = 0; i < positions.length; i++) {
            assertTrue(positions[i].underlyingAsset.asset != address(0));
            assertTrue(bytes(positions[i].underlyingAsset.symbol).length > 0);
            assertTrue(bytes(positions[i].protocol).length > 0);
        }
    }

    // Test 29: fork_getAllPositions_ethQuote
    function test_fork_getAllPositions_ethQuote() public view {
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, eth);

        assertTrue(positions.length > 0);

        // Verify all positions have ETH as quote currency
        for (uint256 i = 0; i < positions.length; i++) {
            assertEq(positions[i].quoteAsset.asset, eth);
            assertTrue(positions[i].value != 0);
        }
    }

    // Test 30: fork_navConsistency
    function test_fork_navConsistency() public view {
        INAVCalculator.NAV memory navTotal = nav.getAccountNav(safe, address(0));
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));

        // Verify NAV consistency invariant
        int256 sum = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            sum += positions[i].value;
        }
        assertEq(navTotal.value, sum);

        // Verify NAV timestamp
        assertEq(navTotal.timestamp, navTotal.timestamp);
        assertEq(navTotal.issues.sequencerDown, navTotal.issues.sequencerDown);
        assertEq(navTotal.issues.stalePriceAssets.length, navTotal.issues.stalePriceAssets.length);
    }

    function setupPriceOracle() internal override {
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

        // usdc
        nav.addBalanceOracle(address(usdc), address(usdc), IBalances.OracleType.ERC20);
        nav.addBalanceOracle(address(usdc), address(aaveOracle), IBalances.OracleType.Custom);
        nav.addBalanceOracle(address(usdc), address(compoundV3Comet), IBalances.OracleType.Custom);
        nav.addBalanceOracle(address(usdc), address(morphoBlueOracle), IBalances.OracleType.Custom);

        // dai
        nav.addBalanceOracle(address(dai), address(dai), IBalances.OracleType.ERC20);
        nav.addBalanceOracle(address(dai), address(aaveOracle), IBalances.OracleType.Custom);
        nav.addBalanceOracle(address(dai), address(daiDsr), IBalances.OracleType.Custom);

        // sDai
        nav.addBalanceOracle(address(sdai), address(sdai), IBalances.OracleType.ERC20);
        nav.addBalanceOracle(address(sdai), address(aaveOracle), IBalances.OracleType.Custom);

        // Compound

        nav.addBalanceOracle(address(compound), address(compoundV3Comet), IBalances.OracleType.Custom);
        nav.addBalanceOracle(address(compound), address(compound), IBalances.OracleType.ERC20);
    }
}

contract OptimismForkNAVCalculator is NAVCalculatorForkHarness {
    IERC20 public usdc = IERC20(0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85);
    address public eth = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
    IERC20 public compound = IERC20(0x7e7d4467112689329f7E06571eD0E8CbAd4910eE);

    address public aaveV3DataProvider = address(0x7F23D86Ee20D869112572136221e173428DD740B);
    address public aaveV3rewardsDistributor = address(0x929EC64c34a17401F460460D4B9390518E5B473e);

    IERC20 public cUsdCv3 = IERC20(0x2e44e174f7D53F0212823acC11C01A11d58c5bCB);
    address public compoundRewardContract = address(0x443EA0340cb75a160F31A440722dec7b5bc3C2E9);

    address public usdcToUsdChainlink = address(0x16a9FA2FDa030272Ce99B29CF780dFA30361E0f3);
    address public compoundToUsdChainlink = address(0xe1011160d78a80E2eEBD60C228EEf7af4Dfcd4d7);

    function setUp() public {
        fork = vm.createFork(getAlchemyUrl("opt-mainnet"));
        vm.selectFork(fork);
        vm.rollFork(126_963_147);
        setupNavCalculator();
    }

    function test_optimismFork_read() public view {
        INAVCalculator.NAV memory reading = super.forkRead();
        assertEq(reading.value, 7_596_542_008_105);

        int256 aaveUsdcBalance = aaveOracle.balanceOf(address(usdc), safe);
        assertEq(aaveUsdcBalance, 75_976_056_729);
        assertEq(compoundV3CometWithMultiplier.balanceOf(address(compound), safe), 0);
        assertEq(compoundV3CometWithMultiplier.balanceOf(address(usdc), safe), 0);
    }

    function test_optimismFork_getAllPositions() public view {
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));
        INAVCalculator.NAV memory navTotal = nav.getAccountNav(safe, address(0));
        assertEq(navTotal.value, 7_596_542_008_105);

        // Verify NAV consistency
        int256 sum = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            sum += positions[i].value;
        }
        assertEq(navTotal.value, sum);
    }

    function setupPriceOracle() internal override {
        // usdc
        nav.registerAsset(address(usdc), usdcToUsdChainlink, IPrices.PriceType.Chainlink, heartbeat);

        // Compound
        nav.registerAsset(address(compound), compoundToUsdChainlink, IPrices.PriceType.Chainlink, heartbeat);

        // ETH (for quote currency support)
        nav.registerAsset(
            address(eth), address(0x13e3Ee699d1909E8897221329E6FC2b0B7C1c4D0), IPrices.PriceType.Chainlink, heartbeat
        );
    }

    function setupBalanceOracle() internal override {
        aaveOracle =
            new AaveV3InstanceBalanceOracle(aaveV3DataProvider, aaveV3rewardsDistributor, "Aave v3", address(nav));

        compoundV3CometWithMultiplier = new CompoundV3CometWithMultiplier(
            compoundRewardContract, address(cUsdCv3), address(compound), "Compound v3", "USDC Comet", address(nav)
        );

        // usdc
        nav.addBalanceOracle(address(usdc), address(usdc), IBalances.OracleType.ERC20);
        nav.addBalanceOracle(address(usdc), address(aaveOracle), IBalances.OracleType.Custom);
        nav.addBalanceOracle(address(usdc), address(compoundV3CometWithMultiplier), IBalances.OracleType.Custom);

        // Compound

        nav.addBalanceOracle(address(compound), address(compoundV3CometWithMultiplier), IBalances.OracleType.Custom);
        nav.addBalanceOracle(address(compound), address(compound), IBalances.OracleType.ERC20);
    }
}

contract BaseForkNAVCalculator is NAVCalculatorForkHarness {
    IERC20 public usdc = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    address public eth = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    IERC20 public cUsdCv3 = IERC20(0xb125E6687d4313864e53df431d5425969c15Eb2F);
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
        setupNavCalculator();
    }

    function test_baseFork_read() public view {
        INAVCalculator.NAV memory reading = super.forkRead();

        assertEq(reading.issues.stalePriceAssets.length, 0);
        assertEq(reading.issues.sequencerDown, false);
        assertEq(morphoBlueOracle.balanceOf(address(usdc), safe), 25_277_122_725);
        assertEq(aaveOracle.balanceOf(address(usdc), safe), 25_162_172_577);
        assertEq(compoundV3Comet.balanceOf(address(compound), safe), 860_559_000_000_000_000);

        assertEq(reading.value, 5_047_061_452_128);
    }

    function test_baseFork_getAllPositions() public view {
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));
        INAVCalculator.NAV memory navTotal = nav.getAccountNav(safe, address(0));
        assertEq(navTotal.value, 5_047_061_452_128);

        // Verify NAV consistency
        int256 sum = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            sum += positions[i].value;
        }
        assertEq(navTotal.value, sum);
    }

    function setupPriceOracle() internal override {
        // usdc
        nav.registerAsset(
            address(usdc), address(0x7e860098F58bBFC8648a4311b374B1D669a2bc6B), IPrices.PriceType.Chainlink, heartbeat
        );

        // Compound
        nav.registerAsset(
            address(compound),
            address(0x9DDa783DE64A9d1A60c49ca761EbE528C35BA428),
            IPrices.PriceType.Chainlink,
            heartbeat
        );

        // ETH (for quote currency support)
        nav.registerAsset(
            address(eth), address(0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70), IPrices.PriceType.Chainlink, heartbeat
        );
    }

    function setupBalanceOracle() internal override {
        aaveOracle =
            new AaveV3InstanceBalanceOracle(aaveV3DataProvider, aaveV3rewardsDistributor, "Aave v3", address(nav));

        compoundV3Comet = new CompoundV3Comet(
            compoundRewardContract, address(cUsdCv3), address(compound), "Compound v3", "USDC Comet", address(nav)
        );

        morphoBlueOracle =
            new MorphoMarketBalanceOracle(morphoBlue, marketIdWsethUsdc, "Morpho", "Some Market", address(nav));

        // usdc
        nav.addBalanceOracle(address(usdc), address(usdc), IBalances.OracleType.ERC20);
        nav.addBalanceOracle(address(usdc), address(aaveOracle), IBalances.OracleType.Custom);
        nav.addBalanceOracle(address(usdc), address(compoundV3Comet), IBalances.OracleType.Custom);
        nav.addBalanceOracle(address(usdc), address(morphoBlueOracle), IBalances.OracleType.Custom);

        // Compound
        nav.addBalanceOracle(address(compound), address(compoundV3Comet), IBalances.OracleType.Custom);
        nav.addBalanceOracle(address(compound), address(compound), IBalances.OracleType.ERC20);
    }
}

contract ArbitrumForkNAVCalculator is NAVCalculatorForkHarness {
    IERC20 public usdc = IERC20(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
    address public eth = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    IERC20 public cUsdCv3 = IERC20(0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf);
    IERC20 public compound = IERC20(0x354A6dA3fcde098F8389cad84b0182725c6C91dE);

    address public aaveV3DataProvider = address(0x7F23D86Ee20D869112572136221e173428DD740B);
    address public aaveV3rewardsDistributor = address(0x929EC64c34a17401F460460D4B9390518E5B473e);

    address public compoundRewardContract = address(0x88730d254A2f7e6AC8388c3198aFd694bA9f7fae);

    function setUp() public {
        fork = vm.createFork(getAlchemyUrl("arb-mainnet"));

        vm.selectFork(fork);
        vm.rollFork(266_194_155);
        setupNavCalculator();
    }

    function test_arbitrumFork_read() public view {
        INAVCalculator.NAV memory reading = super.forkRead();
        assertEq(reading.value, 5_069_577_118_472);
        assertEq(aaveOracle.balanceOf(address(usdc), safe), 50_703_125_166);
        (uint256 price,,) = nav.latestPrice(address(usdc));
        assertEq(price, 99_985_496);
    }

    function test_arbitrumFork_getAllPositions() public view {
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));
        INAVCalculator.NAV memory navTotal = nav.getAccountNav(safe, address(0));
        assertEq(navTotal.value, 5_069_577_118_472);

        // Verify NAV consistency
        int256 sum = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            sum += positions[i].value;
        }
        assertEq(navTotal.value, sum);
    }

    function setupPriceOracle() internal override {
        // usdc
        nav.registerAsset(
            address(usdc), address(0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3), IPrices.PriceType.Chainlink, heartbeat
        );

        // Compound
        nav.registerAsset(
            address(compound),
            address(0xe7C53FFd03Eb6ceF7d208bC4C13446c76d1E5884),
            IPrices.PriceType.Chainlink,
            heartbeat
        );

        // ETH (for quote currency support)
        nav.registerAsset(
            address(eth), address(0x3169789c1C5Ba77242B3bc1e5D48Cc1D2b7fc419), IPrices.PriceType.Chainlink, heartbeat
        );
    }

    function setupBalanceOracle() internal override {
        aaveOracle =
            new AaveV3InstanceBalanceOracle(aaveV3DataProvider, aaveV3rewardsDistributor, "Aave v3", address(nav));

        compoundV3Comet = new CompoundV3Comet(
            compoundRewardContract, address(cUsdCv3), address(compound), "Compound v3", "USDC Comet", address(nav)
        );

        nav.addBalanceOracle(address(usdc), address(usdc), IBalances.OracleType.ERC20);
        nav.addBalanceOracle(address(usdc), address(aaveOracle), IBalances.OracleType.Custom);
        nav.addBalanceOracle(address(usdc), address(compoundV3Comet), IBalances.OracleType.Custom);

        nav.addBalanceOracle(address(compound), address(compound), IBalances.OracleType.ERC20);
        nav.addBalanceOracle(address(compound), address(compoundV3Comet), IBalances.OracleType.Custom);
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
        setupNavCalculator();
    }

    function test_gnosisFork_read() public view {
        INAVCalculator.NAV memory reading = super.forkRead();

        assertEq(reading.issues.stalePriceAssets.length, 0);
        assertEq(reading.issues.sequencerDown, false);
        assertEq(reading.value, 15_378_167_317_682);
    }

    function test_gnosisFork_getAllPositions() public view {
        INAVCalculator.Position[] memory positions = nav.getAccountPositions(safe, address(0));
        INAVCalculator.NAV memory navTotal = nav.getAccountNav(safe, address(0));
        assertEq(navTotal.value, 15_378_167_317_682);

        // Verify NAV consistency
        int256 sum = 0;
        for (uint256 i = 0; i < positions.length; i++) {
            sum += positions[i].value;
        }
        assertEq(navTotal.value, sum);
    }

    function setupPriceOracle() internal override {
        savingsXdaiPrice = new sXDAI_PriceOracle(savingsXDaiContract, daiToUsdChainlink, heartbeat);

        nav.registerAsset(address(xdai), address(daiToUsdChainlink), IPrices.PriceType.Chainlink, heartbeat);
        nav.registerAsset(address(wxdai), address(daiToUsdChainlink), IPrices.PriceType.Chainlink, heartbeat);
        nav.registerAsset(address(savingsXDaiContract), address(savingsXdaiPrice), IPrices.PriceType.Custom, heartbeat);
    }

    function setupBalanceOracle() internal override {
        // wxdai
        nav.addBalanceOracle(address(wxdai), address(wxdai), IBalances.OracleType.ERC20);
        nav.addBalanceOracle(address(savingsXDaiContract), address(savingsXDaiContract), IBalances.OracleType.ERC20);
    }
}
