// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {TestEnvConfigurator} from "test/TestEnvConfigurator.sol";
import {GmxBalanceOracle} from "src/balances/protocols/GMX.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBalanceOracleCustom} from "src/balances/IBalanceOracleCustom.sol";
import "src/errors.sol";
import {NAVCalculator} from "src/nav/NAVCalculator.sol";
import {IPrices} from "src/prices/Prices.sol";
import {MockBalances} from "test/mocks/MockBalances.sol";
import "test/SuperTest.sol";

contract GMXTest is TestEnvConfigurator {
    IERC20 public constant WETH = IERC20(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
    IERC20 public constant USDC = IERC20(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
    IERC20 public constant BTC = IERC20(0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f);
    address public constant synBTC = 0x47904963fc8b2340414262125aF798B9655E58Cd;
    address public constant TEST_USER = 0xd0ca2a7Ed8aeE7972750B085B27350f1Cd387F9b;
    uint256 public constant FORK_BLOCK = 339_673_828;
    address public constant ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address public constant USDC_USD = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address public constant BTC_USD = 0x6ce185860a4963106506C203335A2910413708e9;

    // GMX Protocol addresses
    address public constant GMX_READER = 0x0537C767cDAC0726c76Bb89e92904fe28fd02fE1;
    address public constant GMX_REFERRAL_STORAGE = 0xe6fab3F0c7199b0d34d7FbE83394fc0e0D06e99d;

    // Market addresses
    // https://github.com/gmx-io/gmx-interface/blob/60224f45f859536c35f4096954295ed19aa5cd28/src/config/static/markets.ts#L98
    address public constant WETH_WETH_SHORT_MARKET = 0x450bb6774Dd8a756274E0ab4107953259d2ac541;
    address public constant WETH_USDC_LONG_MARKET = 0x70d95587d40A2caf56bd97485aB3Eec10Bee6336;
    address public constant BTC_USDC_LONG_MARKET = 0x47c031236e19d024b42f8AE6780E44A573170703;

    uint256 public fork;
    GmxBalanceOracle public oracle;
    NAVCalculator public nav;
    address public admin;
    address public ops;
    address public safe;
    MockBalances mockBalances;
    IBalanceOracleCustom.PositionMetadata gmxMetadata = IBalanceOracleCustom.PositionMetadata({
        protocol: "GMX", position: "ETH/USDC-WETH/USDC Long", positionType: "Perpetual"
    });

    function setUp() public {
        // Fork will be created per-test with specific block numbers to reduce RPC calls
        // Oracle creation is moved to individual tests to avoid calling non-contract addresses
        mockBalances = new MockBalances();
    }

    function test_WETH_WETH_Short_firstBlock_Oracle() public {
        fork = vm.createSelectFork(getAlchemyUrl("arb-mainnet"), 341_553_384);

        address user = 0xd0ca2a7Ed8aeE7972750B085B27350f1Cd387F9b;

        GmxBalanceOracle.TokenFeed[] memory feeds = new GmxBalanceOracle.TokenFeed[](2);
        feeds[0] = GmxBalanceOracle.TokenFeed(address(WETH), ETH_USD);
        feeds[1] = GmxBalanceOracle.TokenFeed(address(USDC), USDC_USD);

        oracle = new GmxBalanceOracle(
            WETH_WETH_SHORT_MARKET,
            GMX_READER,
            GMX_REFERRAL_STORAGE,
            address(USDC),
            address(WETH),
            false,
            feeds,
            "GMX",
            "WETH/USDC Short",
            address(mockBalances)
        );

        int256 balanceUsdc = oracle.balanceOf(address(USDC), user);
        int256 balanceWeth = oracle.balanceOf(address(WETH), user);

        assertEq(balanceUsdc, 74_908_975);
        assertEq(balanceWeth, -19_314_468_244_805_026);
    }

    function test_WETH_WETH_Short_WithFees_Oracle() public {
        fork = vm.createSelectFork(getAlchemyUrl("arb-mainnet"), 340_833_501);

        address user = 0xd0ca2a7Ed8aeE7972750B085B27350f1Cd387F9b;

        GmxBalanceOracle.TokenFeed[] memory feeds = new GmxBalanceOracle.TokenFeed[](2);
        feeds[0] = GmxBalanceOracle.TokenFeed(address(WETH), ETH_USD);
        feeds[1] = GmxBalanceOracle.TokenFeed(address(USDC), USDC_USD);

        oracle = new GmxBalanceOracle(
            WETH_WETH_SHORT_MARKET,
            GMX_READER,
            GMX_REFERRAL_STORAGE,
            address(USDC),
            address(WETH),
            false,
            feeds,
            "GMX",
            "WETH/USDC Short",
            address(mockBalances)
        );

        int256 balanceUsdc = oracle.balanceOf(address(USDC), user);
        int256 balanceWeth = oracle.balanceOf(address(WETH), user);

        assertEq(balanceUsdc, 74_905_535);
        assertEq(balanceWeth, -19_314_047_102_943_041);
    }

    function test_WETH_USDC_Long_Oracle() public {
        fork = vm.createSelectFork(getAlchemyUrl("arb-mainnet"), 301_945_721);

        address user = 0xd0ca2a7Ed8aeE7972750B085B27350f1Cd387F9b;

        GmxBalanceOracle.TokenFeed[] memory feeds = new GmxBalanceOracle.TokenFeed[](2);
        feeds[0] = GmxBalanceOracle.TokenFeed(address(WETH), ETH_USD);
        feeds[1] = GmxBalanceOracle.TokenFeed(address(USDC), USDC_USD);

        oracle = new GmxBalanceOracle(
            WETH_USDC_LONG_MARKET,
            GMX_READER,
            GMX_REFERRAL_STORAGE,
            address(USDC),
            address(USDC),
            true,
            feeds,
            "GMX",
            "WETH/USDC Long",
            address(mockBalances)
        );

        int256 balanceWeth = oracle.balanceOf(address(WETH), user);
        int256 balanceUsdc = oracle.balanceOf(address(USDC), user);

        assertEq(balanceUsdc, -654_241_853);
        assertEq(balanceWeth, 223_334_473_924_202_656);
    }

    function test_BTC_USDC_Long_Oracle() public {
        fork = vm.createSelectFork(getAlchemyUrl("arb-mainnet"), 340_833_501);

        address user = 0x08c788aFdACF6cf81180D2bBBE42A7434D0C7A92;

        GmxBalanceOracle.TokenFeed[] memory feeds = new GmxBalanceOracle.TokenFeed[](4);
        feeds[0] = GmxBalanceOracle.TokenFeed(synBTC, BTC_USD);
        feeds[1] = GmxBalanceOracle.TokenFeed(address(USDC), USDC_USD);
        feeds[2] = GmxBalanceOracle.TokenFeed(address(USDC), USDC_USD);
        feeds[0] = GmxBalanceOracle.TokenFeed(address(BTC), BTC_USD);

        oracle = new GmxBalanceOracle(
            BTC_USDC_LONG_MARKET,
            GMX_READER,
            GMX_REFERRAL_STORAGE,
            address(USDC),
            address(USDC),
            true,
            feeds,
            "GMX",
            "BTC/USDC Long",
            address(mockBalances)
        );

        int256 balanceBTC = oracle.balanceOf(address(BTC), user);
        int256 balanceUsdc = oracle.balanceOf(address(USDC), user);

        assertEq(balanceUsdc, -17_778_578_381_862);
        assertEq(balanceBTC, 19_590_279_063);
    }

    function test_WETH_USDC_Long_Whale1_Oracle() public {
        fork = vm.createSelectFork(getAlchemyUrl("arb-mainnet"), 341_593_396);

        address user = 0x91666112b851E33D894288A95846d14781e86cad;

        GmxBalanceOracle.TokenFeed[] memory feeds = new GmxBalanceOracle.TokenFeed[](2);
        feeds[0] = GmxBalanceOracle.TokenFeed(address(WETH), ETH_USD);
        feeds[1] = GmxBalanceOracle.TokenFeed(address(USDC), USDC_USD);

        oracle = new GmxBalanceOracle(
            WETH_USDC_LONG_MARKET,
            GMX_READER,
            GMX_REFERRAL_STORAGE,
            address(USDC),
            address(USDC),
            true,
            feeds,
            "GMX",
            "WETH/USDC Long",
            address(mockBalances)
        );

        int256 balanceUsdc = oracle.balanceOf(address(USDC), user);
        int256 balanceWeth = oracle.balanceOf(address(WETH), user);

        assertLt(balanceUsdc, -4_148_308_901_095);
        assertEq(balanceWeth, 3_263_145_687_143_886_967_869);
    }

    function test_WETH_USDC_Long_Whale2_Oracle() public {
        fork = vm.createSelectFork(getAlchemyUrl("arb-mainnet"), 341_593_396);

        address user = 0xe2823659bE02E0F48a4660e4Da008b5E1aBFdF29;

        GmxBalanceOracle.TokenFeed[] memory feeds = new GmxBalanceOracle.TokenFeed[](2);
        feeds[0] = GmxBalanceOracle.TokenFeed(address(WETH), ETH_USD);
        feeds[1] = GmxBalanceOracle.TokenFeed(address(USDC), USDC_USD);

        oracle = new GmxBalanceOracle(
            WETH_USDC_LONG_MARKET,
            GMX_READER,
            GMX_REFERRAL_STORAGE,
            address(USDC),
            address(USDC),
            true,
            feeds,
            "GMX",
            "WETH/USDC Long",
            address(mockBalances)
        );

        int256 balanceUsdc = oracle.balanceOf(address(USDC), user);
        int256 balanceWeth = oracle.balanceOf(address(WETH), user);

        assertLt(balanceUsdc, -1_393_558_062_500);
        assertEq(balanceWeth, 775_713_648_496_240_752_489);
    }

    function test_balanceOfZeroAddress() public {
        fork = vm.createSelectFork(getAlchemyUrl("arb-mainnet"), FORK_BLOCK);

        GmxBalanceOracle.TokenFeed[] memory feeds = new GmxBalanceOracle.TokenFeed[](1);
        feeds[0] = GmxBalanceOracle.TokenFeed(address(WETH), ETH_USD);

        oracle = new GmxBalanceOracle(
            BTC_USDC_LONG_MARKET,
            GMX_READER,
            GMX_REFERRAL_STORAGE,
            address(USDC),
            address(WETH),
            false,
            feeds,
            "GMX",
            "BTC/USDC Short",
            address(mockBalances)
        );

        int256 balanceWeth = oracle.balanceOf(address(WETH), address(0));
        assertEq(balanceWeth, 0);

        int256 balanceUsdc = oracle.balanceOf(address(USDC), address(0));
        assertEq(balanceUsdc, 0);
    }

    // NAV Tests
    //    function test_WETH_WETH_Short_firstBlock_NAV() public {
    //        vm.selectFork(fork);
    //        vm.rollFork(341_553_384);
    //
    //        address user = 0xd0ca2a7Ed8aeE7972750B085B27350f1Cd387F9b;
    //
    //        GMX.TokenFeed[] memory feeds = new GMX.TokenFeed[](2);
    //        feeds[0] = GMX.TokenFeed(address(WETH), ETH_USD);
    //        feeds[1] = GMX.TokenFeed(address(USDC), USDC_USD);
    //
    //        oracle = new GMX(
    //            WETH_WETH_SHORT_MARKET, GMX_READER, GMX_REFERRAL_STORAGE, address(USDC), address(WETH), false, feeds
    //        );
    //
    //        deployNavCalculator();
    //
    //        // Add GMX oracle to NAV calculator
    //        vm.startPrank(ops);
    //        nav.addBalance(address(WETH), address(oracle), IBalances.BalanceType.Custom);
    //        nav.addBalance(address(USDC), address(oracle), IBalances.BalanceType.Custom);
    //        vm.stopPrank();
    //
    //        // Test NAV calculation
    //        INAVCalculator.NAV memory navReading = nav.read(user);
    //        assertEq(navReading.usd, 2_381_760_818);
    //    }
    //
    //    function test_WETH_WETH_Short_WithFees_NAV() public {
    //        vm.selectFork(fork);
    //        vm.rollFork(340_833_501);
    //
    //        address user = 0xd0ca2a7Ed8aeE7972750B085B27350f1Cd387F9b;
    //
    //        GMX.TokenFeed[] memory feeds = new GMX.TokenFeed[](2);
    //        feeds[0] = GMX.TokenFeed(address(WETH), ETH_USD);
    //        feeds[1] = GMX.TokenFeed(address(USDC), USDC_USD);
    //
    //        oracle = new GMX(
    //            WETH_WETH_SHORT_MARKET, GMX_READER, GMX_REFERRAL_STORAGE, address(USDC), address(WETH), false, feeds
    //        );
    //
    //        deployNavCalculator();
    //
    //        // Add GMX oracle to NAV calculator
    //        vm.startPrank(ops);
    //        nav.addBalance(address(WETH), address(oracle), IBalances.BalanceType.Custom);
    //        nav.addBalance(address(USDC), address(oracle), IBalances.BalanceType.Custom);
    //        vm.stopPrank();
    //
    //        // Test NAV calculation
    //        INAVCalculator.NAV memory navReading = nav.read(user);
    //        assertEq(navReading.usd, 2_569_437_379);
    //    }
    //
    //    function test_WETH_USDC_Long_NAV() public {
    //        vm.selectFork(fork);
    //        vm.rollFork(301_945_721);
    //
    //        address user = 0xd0ca2a7Ed8aeE7972750B085B27350f1Cd387F9b;
    //
    //        GMX.TokenFeed[] memory feeds = new GMX.TokenFeed[](2);
    //        feeds[0] = GMX.TokenFeed(address(WETH), ETH_USD);
    //        feeds[1] = GMX.TokenFeed(address(USDC), USDC_USD);
    //
    //        oracle =
    //            new GMX(WETH_USDC_LONG_MARKET, GMX_READER, GMX_REFERRAL_STORAGE, address(USDC), address(USDC), true,
    // feeds);
    //
    //        deployNavCalculator();
    //
    //        // Add GMX oracle to NAV calculator
    //        vm.startPrank(ops);
    //        nav.addBalance(address(WETH), address(oracle), IBalances.BalanceType.Custom);
    //        nav.addBalance(address(USDC), address(oracle), IBalances.BalanceType.Custom);
    //        vm.stopPrank();
    //
    //        // Test NAV calculation
    //        INAVCalculator.NAV memory navReading = nav.read(user);
    //        assertEq(navReading.usd, 518_011_518);
    //    }
    //
    //    function test_BTC_USDC_Long_NAV() public {
    //        vm.selectFork(fork);
    //        vm.rollFork(340_833_501);
    //
    //        address user = 0x08c788aFdACF6cf81180D2bBBE42A7434D0C7A92;
    //
    //        GMX.TokenFeed[] memory feeds = new GMX.TokenFeed[](4);
    //        feeds[0] = GMX.TokenFeed(synBTC, BTC_USD);
    //        feeds[1] = GMX.TokenFeed(address(USDC), USDC_USD);
    //        feeds[2] = GMX.TokenFeed(address(USDC), USDC_USD);
    //        feeds[0] = GMX.TokenFeed(address(BTC), BTC_USD);
    //
    //        oracle =
    //            new GMX(BTC_USDC_LONG_MARKET, GMX_READER, GMX_REFERRAL_STORAGE, address(USDC), address(USDC), true,
    // feeds);
    //
    //        deployNavCalculator();
    //
    //        // Add GMX oracle to NAV calculator
    //        vm.startPrank(ops);
    //        nav.addBalance(address(BTC), address(oracle), IBalances.BalanceType.Custom);
    //        nav.addBalance(address(USDC), address(oracle), IBalances.BalanceType.Custom);
    //        vm.stopPrank();
    //
    //        // Test NAV calculation
    //        INAVCalculator.NAV memory navReading = nav.read(user);
    //        assertEq(navReading.usd, 362_891_683_394_960);
    //    }
    //
    //    function test_WETH_USDC_Long_Whale1_NAV() public {
    //        vm.selectFork(fork);
    //        vm.rollFork(341_593_396);
    //
    //        address user = 0x91666112b851E33D894288A95846d14781e86cad;
    //
    //        GMX.TokenFeed[] memory feeds = new GMX.TokenFeed[](2);
    //        feeds[0] = GMX.TokenFeed(address(WETH), ETH_USD);
    //        feeds[1] = GMX.TokenFeed(address(USDC), USDC_USD);
    //
    //        oracle =
    //            new GMX(WETH_USDC_LONG_MARKET, GMX_READER, GMX_REFERRAL_STORAGE, address(USDC), address(USDC), true,
    // feeds);
    //
    //        deployNavCalculator();
    //
    //        // Add GMX oracle to NAV calculator
    //        vm.startPrank(ops);
    //        nav.addBalance(address(WETH), address(oracle), IBalances.BalanceType.Custom);
    //        nav.addBalance(address(USDC), address(oracle), IBalances.BalanceType.Custom);
    //        vm.stopPrank();
    //
    //        // Test NAV calculation
    //        INAVCalculator.NAV memory navReading = nav.read(user);
    //        assertEq(navReading.usd, 465_558_583_875_319);
    //    }
    //
    //    function test_WETH_USDC_Long_Whale2_NAV() public {
    //        vm.selectFork(fork);
    //        vm.rollFork(341_593_396);
    //
    //        address user = 0xe2823659bE02E0F48a4660e4Da008b5E1aBFdF29;
    //
    //        GMX.TokenFeed[] memory feeds = new GMX.TokenFeed[](2);
    //        feeds[0] = GMX.TokenFeed(address(WETH), ETH_USD);
    //        feeds[1] = GMX.TokenFeed(address(USDC), USDC_USD);
    //
    //        oracle =
    //            new GMX(WETH_USDC_LONG_MARKET, GMX_READER, GMX_REFERRAL_STORAGE, address(USDC), address(USDC), true,
    // feeds);
    //
    //        deployNavCalculator();
    //
    //        // Add GMX oracle to NAV calculator
    //        vm.startPrank(ops);
    //        nav.addBalance(address(WETH), address(oracle), IBalances.BalanceType.Custom);
    //        nav.addBalance(address(USDC), address(oracle), IBalances.BalanceType.Custom);
    //        vm.stopPrank();
    //
    //        // Test NAV calculation
    //        INAVCalculator.NAV memory navReading = nav.read(user);
    //        assertEq(navReading.usd, 71_114_693_808_806);
    //    }

    function deployNavCalculator() internal {
        // Setup NAV Calculator
        admin = makeAddr("admin");
        ops = makeAddr("ops");
        safe = makeAddr("safe");

        address navImpl = address(new NAVCalculator());
        address navProxy = UnsafeUpgrades.deployUUPSProxy(
            navImpl, abi.encodeCall(NAVCalculator.initialize, (admin, safe, address(0)))
        );
        nav = NAVCalculator(navProxy);

        vm.startPrank(admin);
        // Grant roles
        nav.grantRole(OPERATOR, ops);

        vm.stopPrank();

        // Setup price oracles
        vm.startPrank(ops);
        nav.registerAsset(address(WETH), ETH_USD, IPrices.PriceType.Chainlink, 3600);
        nav.registerAsset(address(USDC), USDC_USD, IPrices.PriceType.Chainlink, 3600);
        nav.registerAsset(address(BTC), BTC_USD, IPrices.PriceType.Chainlink, 3600);

        vm.stopPrank();
    }
}
